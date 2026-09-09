import 'package:json_annotation/json_annotation.dart';

part 'model_132.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model132 {
  const Model132({required this.id, required this.value});

  final int id;
  final String value;

  factory Model132.fromJson(Map<String, dynamic> json) =>
      _$Model132FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model132ToJson(this);
}
