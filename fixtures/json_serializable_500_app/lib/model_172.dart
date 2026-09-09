import 'package:json_annotation/json_annotation.dart';

part 'model_172.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model172 {
  const Model172({required this.id, required this.value});

  final int id;
  final String value;

  factory Model172.fromJson(Map<String, dynamic> json) =>
      _$Model172FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model172ToJson(this);
}
