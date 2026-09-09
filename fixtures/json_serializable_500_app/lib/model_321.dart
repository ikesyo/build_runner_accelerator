import 'package:json_annotation/json_annotation.dart';

part 'model_321.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model321 {
  const Model321({required this.id, required this.value});

  final int id;
  final String value;

  factory Model321.fromJson(Map<String, dynamic> json) =>
      _$Model321FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model321ToJson(this);
}
