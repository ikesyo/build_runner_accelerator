import 'package:json_annotation/json_annotation.dart';

part 'model_266.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model266 {
  const Model266({required this.id, required this.value});

  final int id;
  final String value;

  factory Model266.fromJson(Map<String, dynamic> json) =>
      _$Model266FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model266ToJson(this);
}
