import 'package:json_annotation/json_annotation.dart';

part 'model_086.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model086 {
  const Model086({required this.id, required this.value});

  final int id;
  final String value;

  factory Model086.fromJson(Map<String, dynamic> json) =>
      _$Model086FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model086ToJson(this);
}
