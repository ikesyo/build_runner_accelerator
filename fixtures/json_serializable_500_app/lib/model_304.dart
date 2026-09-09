import 'package:json_annotation/json_annotation.dart';

part 'model_304.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model304 {
  const Model304({required this.id, required this.value});

  final int id;
  final String value;

  factory Model304.fromJson(Map<String, dynamic> json) =>
      _$Model304FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model304ToJson(this);
}
