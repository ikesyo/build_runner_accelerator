import 'package:json_annotation/json_annotation.dart';

part 'model_243.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model243 {
  const Model243({required this.id, required this.value});

  final int id;
  final String value;

  factory Model243.fromJson(Map<String, dynamic> json) =>
      _$Model243FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model243ToJson(this);
}
