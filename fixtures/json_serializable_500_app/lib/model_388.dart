import 'package:json_annotation/json_annotation.dart';

part 'model_388.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model388 {
  const Model388({required this.id, required this.value});

  final int id;
  final String value;

  factory Model388.fromJson(Map<String, dynamic> json) =>
      _$Model388FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model388ToJson(this);
}
