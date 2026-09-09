import 'package:json_annotation/json_annotation.dart';

part 'model_121.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model121 {
  const Model121({required this.id, required this.value});

  final int id;
  final String value;

  factory Model121.fromJson(Map<String, dynamic> json) =>
      _$Model121FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model121ToJson(this);
}
