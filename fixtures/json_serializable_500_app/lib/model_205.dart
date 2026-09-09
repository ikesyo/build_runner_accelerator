import 'package:json_annotation/json_annotation.dart';

part 'model_205.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model205 {
  const Model205({required this.id, required this.value});

  final int id;
  final String value;

  factory Model205.fromJson(Map<String, dynamic> json) =>
      _$Model205FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model205ToJson(this);
}
